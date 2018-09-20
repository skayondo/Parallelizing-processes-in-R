##Change this if you are using this for a server, where the packages are installed on your command line
#r_package_loc <- 
r_package_loc <- NULL


##These are the necessary libraries that we use. I foud that R on our server didn't like the library(tidyverse), 
##so I needed to load each package individually
requiredPackages = c('tibble','tidyr','dplyr','readr','rrBLUP'
                     ,'data.table','doSNOW')
                       
                       
for(p in requiredPackages){
  if(!require(p,character.only = TRUE)) install.packages(p)
  library(p,character.only = TRUE,lib.loc = r_package_loc)
}

##This loads the training data. It is a matrix of indviduals x SNP markers
gen_train <- fread("Script-Example/Training_Imputed_Subset.rrblup")
gen_train <- as.matrix(gen_train)

##This is key that tracks the individual name with the marker data. This is important for tracking the
##phenotype data for each invidual
genID <- read_tsv("Script-Example/Training_Imputed.012.indv",
                  col_names = FALSE) %>% 
  rename(Genotype = 'X1') %>% 
  mutate(Gen_Ord = row_number())

phenotypes <- read_tsv("Script-Example/BLUPs.txt") %>% 
  mutate(Genotype = toupper(Genotype)) %>% 
  mutate(Genotype = case_when(
    Genotype == "W22_R-RSTD" ~ "W22R-R-STD_CS-2909-1",
    TRUE ~ Genotype
  )) %>% 
  left_join(genID,
            by = "Genotype") %>% 
  arrange(Gen_Ord) %>% 
  gather(Trait,Value,-Genotype,-Gen_Ord)


##This is my cross-validation function, splits the data into training and validation data and then
##runs the prediction and compares the accuracy. It returns a row of information
cross_val <- function(Z,y,crossFold,curTrait) {
  y_form <- y %>%
    filter(Trait == curTrait) %>% 
    na.omit()
  
  ran <- y_form %>% 
    select(Gen_Ord) %>% 
    mutate(GenNum = sample(1:nrow(y_form),replace = FALSE),
           Group = as.numeric(cut(GenNum,crossFold)))
    
  
  valid_set <- NULL
  for (i in 1:crossFold) {
    train_Z <- Z[ran %>% 
                      filter(Group != i) %>% 
                      pull(Gen_Ord),]
    
    train_y <- ran %>%
      filter(Group != i) %>% 
      select(Gen_Ord) %>%
      arrange(Gen_Ord) %>% 
      left_join(y_form,
                by = "Gen_Ord") %>% 
      pull(Value)
    
    val_Z <- Z[ran %>% 
                      filter(Group == i) %>% 
                      pull(Gen_Ord),]
    val_y <- ran %>%
      filter(Group == i) %>% 
      select(Gen_Ord) %>%
      arrange(Gen_Ord) %>% 
      left_join(y_form,
                by = "Gen_Ord") %>% 
      pull(Value)
    
    ans <- mixed.solve(y = train_y,
                       Z = train_Z)
    valid_set <- rbind(valid_set,data.frame(Pred = val_Z %*% as.matrix(ans$u) + as.vector(ans$beta),
                                            True = val_y)) 
  }
  return(cor(valid_set$Pred,
             valid_set$True))
  gc()
}

##This sets up a matrix for specifying the variables we are putting into the function
kfold <- NULL 
folds <- c(2)
reps <- 2
traits <- phenotypes %>% 
  select(Trait) %>%
  unique() %>%
  pull(Trait)

for(i in 1:length(traits)) {
  for (j in 1:length(folds)) {
    kfold <- rbind(kfold,
                   cbind(Rep = seq(1:reps),
                         Fold = rep(folds[j],reps),
                         Trait = rep(traits[i],reps),
                         Cor = NA)) 
  }
}

kfold <- as.tibble(kfold) %>% 
  mutate(Rep = as.numeric(Rep),
         Fold = as.numeric(Fold))

##This is a way to track the progress of the multi-parrallel functions
pb <- txtProgressBar(max = nrow(kfold), style = 3)
progress <- function(n) setTxtProgressBar(pb, n)
opts <- list(progress = progress)


##This is important for clarifying the number of clusters/nodes/ that you are running
cl <- makeSOCKcluster(2)
registerDoSNOW(cl)

##This runs the for loop and sends the necessary data to each cluster/node
kfold_out <- foreach(i = 1:nrow(kfold),
                     .combine = 'rbind',
                     .packages = c('tibble','dplyr','tidyr','rrBLUP'),
                     .options.snow = opts) %dopar% {
                       out <- c(unlist(kfold[i,1:3]), cross_val(Z = gen_train,
                                                     y = phenotypes,
                                                     curTrait = kfold$Trait[i],
                                                     crossFold = kfold$Fold[i]))
                       return(out)
                     }

##This stops all the clusters to free up the space
stopCluster(cl)

##Write the output
write_tsv(path = "Script-Example/Results.txt",
          x = as.tibble(kfold_out))

